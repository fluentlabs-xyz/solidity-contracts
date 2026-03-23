// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {BridgeBase} from "./Base.t.sol";

contract BridgePauserTest is BridgeBase {
    function _pauseBoth() internal {
        vm.prank(pauser);
        l1Bridge.pause();
        vm.prank(pauser);
        l2Bridge.pause();
    }

    function test_RevertIf_sendMessage_pausedOnL1() public {
        vm.prank(pauser);
        l1Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        l1Bridge.sendMessage(makeAddr("dst1"), hex"1234");
    }

    function test_RevertIf_sendMessage_pausedOnL2() public {
        vm.prank(pauser);
        l2Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        l2Bridge.sendMessage(makeAddr("dst2"), hex"5678");
    }

    function test_RevertIf_receiveMessage_pausedOnL1() public {
        vm.prank(pauser);
        l1Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(relayer);
        l1Bridge.receiveMessage(makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "");
    }

    function test_RevertIf_receiveMessage_pausedOnL2() public {
        vm.prank(pauser);
        l2Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(relayer);
        l2Bridge.receiveMessage(makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "");
    }

    function test_RevertIf_receiveFailedMessage_pausedOnL1() public {
        vm.prank(pauser);
        l1Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        l1Bridge.receiveFailedMessage(makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "");
    }

    function test_RevertIf_receiveFailedMessage_pausedOnL2() public {
        vm.prank(pauser);
        l2Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        l2Bridge.receiveFailedMessage(makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "");
    }

    function test_RevertIf_receiveMessageWithProof_paused() public {
        vm.prank(pauser);
        l1Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        l1Bridge.receiveMessageWithProof(
            0,
            _dummyHeader(),
            makeAddr("from"),
            payable(makeAddr("to")),
            0,
            1,
            1,
            0,
            "",
            _dummyProof(),
            _dummyProof()
        );
    }

    function test_RevertIf_rollbackMessageWithProof_paused() public {
        vm.prank(pauser);
        l1Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        l1Bridge.rollbackMessageWithProof(0, _dummyHeader(), makeAddr("from"), makeAddr("to"), 0, 1, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_sendMessage_worksAfterUnpause() public {
        vm.prank(pauser);
        l2Bridge.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        l2Bridge.sendMessage(makeAddr("dst"), hex"01");

        vm.prank(pauser);
        l2Bridge.unpause();

        l2Bridge.sendMessage(makeAddr("dst"), hex"01");
        assertEq(l2Bridge.getNonce(), 1);
    }
}
