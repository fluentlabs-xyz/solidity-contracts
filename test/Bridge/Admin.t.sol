// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IFluentBridgeEvents} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../contracts/interfaces/bridge/IL1FluentBridge.sol";
import {IL2FluentBridge} from "../../contracts/interfaces/bridge/IL2FluentBridge.sol";
import {BridgeBase} from "./Base.t.sol";

contract BridgeAdminTest is BridgeBase {
    function test_setOtherBridge_updatesAddress() public {
        address prev = l1Bridge.getOtherBridge();
        address next = makeAddr("nextL1OtherBridge");
        vm.expectEmit(true, true, true, true, address(l1Bridge));
        emit IFluentBridgeEvents.OtherBridgeUpdated(prev, next);
        vm.prank(admin);
        l1Bridge.setOtherBridge(next);
        assertEq(l1Bridge.getOtherBridge(), next);
    }

    function test_RevertIf_setOtherBridge_callerNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l1Bridge.DEFAULT_ADMIN_ROLE())
        );
        vm.prank(stranger);
        l1Bridge.setOtherBridge(makeAddr("nextL1OtherBridge"));
    }

    function test_RevertIf_setOtherBridge_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "otherBridge"));
        vm.prank(admin);
        l1Bridge.setOtherBridge(address(0));
    }

    function test_setExecuteGasLimit_updatesValue() public {
        uint256 prev = l1Bridge.getExecuteGasLimit();
        vm.expectEmit(true, true, true, true, address(l1Bridge));
        emit IFluentBridgeEvents.ExecuteGasLimitUpdated(prev, 250_000);
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
        vm.expectEmit(true, true, true, true, address(l1Bridge));
        emit IAccessControl.RoleGranted(l1Bridge.RELAYER_ROLE(), nextRelayer, admin);
        vm.prank(admin);
        l1Bridge.setRelayerRole(nextRelayer);
        assertTrue(l1Bridge.hasRole(l1Bridge.RELAYER_ROLE(), nextRelayer));
    }

    function test_RevertIf_setRollup_callerNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l1Bridge.DEFAULT_ADMIN_ROLE())
        );
        vm.prank(stranger);
        l1Bridge.setRollup(makeAddr("rollupB"));
    }

    function test_RevertIf_setRollup_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "rollup"));
        vm.prank(admin);
        l1Bridge.setRollup(address(0));
    }

    function test_setRollup_updatesAddress() public {
        address prev = l1Bridge.getRollup();
        address nextRollup = makeAddr("rollupB");
        vm.expectEmit(true, true, true, true, address(l1Bridge));
        emit IL1FluentBridge.RollupUpdated(prev, nextRollup);
        vm.prank(admin);
        l1Bridge.setRollup(nextRollup);
        assertEq(l1Bridge.getRollup(), nextRollup);
    }

    function test_setReceiveMessageDeadline_updatesValue() public {
        uint256 prev = l2Bridge.getReceiveMessageDeadline();
        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit IL2FluentBridge.ReceiveMessageDeadlineUpdated(prev, 777);
        vm.prank(admin);
        l2Bridge.setReceiveMessageDeadline(777);
        assertEq(l2Bridge.getReceiveMessageDeadline(), 777);
    }

    function test_RevertIf_setReceiveMessageDeadline_callerNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l2Bridge.DEFAULT_ADMIN_ROLE())
        );
        vm.prank(stranger);
        l2Bridge.setReceiveMessageDeadline(777);
    }

    function test_RevertIf_setReceiveMessageDeadline_zeroValue() public {
        vm.expectRevert(
            abi.encodeWithSelector(IFluentBridgeErrors.InvalidWindowConfig.selector, "receiveMessageDeadline must be greater than 0")
        );
        vm.prank(admin);
        l2Bridge.setReceiveMessageDeadline(0);
    }

    function test_setL1BlockOracle_updatesAddress() public {
        address prev = l2Bridge.getL1BlockOracle();
        address nextOracle = makeAddr("l1BlockOracleB");
        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit IL2FluentBridge.L1BlockOracleUpdated(prev, nextOracle);
        vm.prank(admin);
        l2Bridge.setL1BlockOracle(nextOracle);
        assertEq(l2Bridge.getL1BlockOracle(), nextOracle);
    }

    function test_RevertIf_setL1BlockOracle_callerNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l2Bridge.DEFAULT_ADMIN_ROLE())
        );
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
        vm.expectEmit(true, true, true, true, address(l1Bridge));
        emit PausableUpgradeable.Paused(pauser);
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
        vm.expectEmit(true, true, true, true, address(l1Bridge));
        emit PausableUpgradeable.Unpaused(pauser);
        vm.prank(pauser);
        l1Bridge.unpause();
        assertFalse(l1Bridge.paused());
    }

    function test_RevertIf_setFeeTreasury_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "newFeeTreasury"));
        vm.prank(admin);
        l2Bridge.setFeeTreasury(address(0));
    }

    function test_RevertIf_setRelayerRole_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "relayer"));
        vm.prank(admin);
        l1Bridge.setRelayerRole(address(0));
    }

    function test_removeRelayerRole_revokesRole() public {
        assertTrue(l1Bridge.hasRole(l1Bridge.RELAYER_ROLE(), relayer));
        vm.expectEmit(true, true, true, true, address(l1Bridge));
        emit IAccessControl.RoleRevoked(l1Bridge.RELAYER_ROLE(), relayer, admin);
        vm.prank(admin);
        l1Bridge.removeRelayerRole(relayer);
        assertFalse(l1Bridge.hasRole(l1Bridge.RELAYER_ROLE(), relayer));
    }

    function test_setFeeTreasury_updatesAddress() public {
        address prev = l2Bridge.getFeeTreasury();
        address nextTreasury = makeAddr("nextTreasury");
        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit IFluentBridgeEvents.FeeTreasuryUpdated(prev, nextTreasury);
        vm.prank(admin);
        l2Bridge.setFeeTreasury(nextTreasury);
        assertEq(l2Bridge.getFeeTreasury(), nextTreasury);
    }

    function test_RevertIf_setFeeTreasury_callerNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l2Bridge.DEFAULT_ADMIN_ROLE())
        );
        vm.prank(stranger);
        l2Bridge.setFeeTreasury(makeAddr("newTreasury"));
    }

    function test_RevertIf_setRelayerRole_callerNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l1Bridge.DEFAULT_ADMIN_ROLE())
        );
        vm.prank(stranger);
        l1Bridge.setRelayerRole(makeAddr("newRelayer"));
    }

    function test_RevertIf_removeRelayerRole_callerNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, l1Bridge.DEFAULT_ADMIN_ROLE())
        );
        vm.prank(stranger);
        l1Bridge.removeRelayerRole(relayer);
    }
}
