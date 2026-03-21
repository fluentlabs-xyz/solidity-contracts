// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../contracts/interfaces/bridge/IL1FluentBridge.sol";
import {BridgeBase} from "./Base.t.sol";

contract BridgeAdminTest is BridgeBase {
    function test_setOtherBridge_updatesAddress() public {
        address next = makeAddr("nextL1OtherBridge");
        vm.prank(admin);
        l1Bridge.setOtherBridge(next);
        assertEq(l1Bridge.getOtherBridge(), next);
    }

    function test_RevertIf_setOtherBridge_callerNotAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l1Bridge.DEFAULT_ADMIN_ROLE()));
        vm.prank(stranger);
        l1Bridge.setOtherBridge(makeAddr("nextL1OtherBridge"));
    }

    function test_RevertIf_setOtherBridge_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "otherBridge"));
        vm.prank(admin);
        l1Bridge.setOtherBridge(address(0));
    }

    function test_setExecuteGasLimit_updatesValue() public {
        vm.prank(admin);
        l1Bridge.setExecuteGasLimit(250_000);
        assertEq(l1Bridge.getExecuteGasLimit(), 250_000);
    }

    function test_RevertIf_setExecuteGasLimit_zeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.InvalidWindowConfig.selector, "executeGasLimit must be greater than 0"));
        vm.prank(admin);
        l1Bridge.setExecuteGasLimit(0);
    }

    function test_setRelayerRole_grantsRole() public {
        address nextRelayer = makeAddr("nextRelayerL1");
        vm.prank(admin);
        l1Bridge.setRelayerRole(nextRelayer);
        assertTrue(l1Bridge.hasRole(l1Bridge.RELAYER_ROLE(), nextRelayer));
    }

    function test_RevertIf_setRollup_callerNotAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l1Bridge.DEFAULT_ADMIN_ROLE()));
        vm.prank(stranger);
        l1Bridge.setRollup(makeAddr("rollupB"));
    }

    function test_RevertIf_setRollup_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "rollup"));
        vm.prank(admin);
        l1Bridge.setRollup(address(0));
    }

    function test_setRollup_updatesAddress() public {
        address nextRollup = makeAddr("rollupB");
        vm.prank(admin);
        l1Bridge.setRollup(nextRollup);
        assertEq(l1Bridge.getRollup(), nextRollup);
    }

    function test_setReceiveMessageDeadline_updatesValue() public {
        vm.prank(admin);
        l2Bridge.setReceiveMessageDeadline(777);
        assertEq(l2Bridge.getReceiveMessageDeadline(), 777);
    }

    function test_RevertIf_setReceiveMessageDeadline_callerNotAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l2Bridge.DEFAULT_ADMIN_ROLE()));
        vm.prank(stranger);
        l2Bridge.setReceiveMessageDeadline(777);
    }

    function test_RevertIf_setReceiveMessageDeadline_zeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.InvalidWindowConfig.selector, "receiveMessageDeadline must be greater than 0"));
        vm.prank(admin);
        l2Bridge.setReceiveMessageDeadline(0);
    }

    function test_setL1BlockOracle_updatesAddress() public {
        address nextOracle = makeAddr("l1BlockOracleB");
        vm.prank(admin);
        l2Bridge.setL1BlockOracle(nextOracle);
        assertEq(l2Bridge.getL1BlockOracle(), nextOracle);
    }

    function test_RevertIf_setL1BlockOracle_callerNotAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l2Bridge.DEFAULT_ADMIN_ROLE()));
        vm.prank(stranger);
        l2Bridge.setL1BlockOracle(makeAddr("l1BlockOracleB"));
    }

    function test_RevertIf_setL1BlockOracle_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "l1BlockOracle"));
        vm.prank(admin);
        l2Bridge.setL1BlockOracle(address(0));
    }

    function test_RevertIf_pause_callerNotPauser() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l1Bridge.PAUSER_ROLE()));
        vm.prank(stranger);
        l1Bridge.pause();
    }

    function test_pause_pausesBridge() public {
        vm.prank(pauser);
        l1Bridge.pause();
        assertTrue(l1Bridge.paused());
    }

    function test_RevertIf_unpause_callerNotPauser() public {
        vm.prank(pauser);
        l1Bridge.pause();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l1Bridge.PAUSER_ROLE()));
        vm.prank(stranger);
        l1Bridge.unpause();
    }

    function test_unpause_unpausesBridge() public {
        vm.prank(pauser);
        l1Bridge.pause();
        vm.prank(pauser);
        l1Bridge.unpause();
        assertFalse(l1Bridge.paused());
    }
}
