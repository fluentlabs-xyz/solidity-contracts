// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FluentBridge as Bridge} from "../../contracts/FluentBridge.sol";
import {IBridgeErrorCodes} from "../../contracts/interfaces/IFluentBridge.sol";
import {MinimalTest} from "../Rollup/Base.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BridgeAdminTest is MinimalTest {
    address internal constant INITIAL_AUTHORITY = address(0xA0A0);
    address internal constant INITIAL_ROLLUP = address(0xB0B0);
    address internal constant INITIAL_OTHER_BRIDGE = address(0xC0C0);
    address internal constant INITIAL_ORACLE = address(0xD0D0);
    address internal constant ATTACKER = address(0xBAD);
    uint256 internal constant INITIAL_DEADLINE = 10;

    Bridge internal bridge;

    function setUp() public {
        Bridge bridgeImpl = new Bridge();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(
                Bridge.initialize,
                (
                    address(this),
                    INITIAL_AUTHORITY,
                    INITIAL_ROLLUP,
                    INITIAL_DEADLINE,
                    INITIAL_OTHER_BRIDGE,
                    INITIAL_ORACLE
                )
            )
        );
        bridge = Bridge(payable(address(proxy)));
    }

    function test_getters_exposeInitialConfig() public view {
        assertEq(bridge.bridgeAuthority(), INITIAL_AUTHORITY, "bridgeAuthority mismatch");
        assertEq(bridge.rollup(), INITIAL_ROLLUP, "rollup mismatch");
        assertEq(bridge.receiveMessageDeadline(), INITIAL_DEADLINE, "deadline mismatch");
        assertEq(bridge.otherBridge(), INITIAL_OTHER_BRIDGE, "otherBridge mismatch");
        assertEq(bridge.l1BlockOracle(), INITIAL_ORACLE, "oracle mismatch");
    }

    function test_setters_updateState() public {
        address newAuthority = address(0xA0A1);
        address newRollup = address(0xB0B1);
        address newOtherBridge = address(0xC0C1);
        address newOracle = address(0xD0D1);

        bridge.setBridgeAuthority(newAuthority);
        bridge.setRollup(newRollup);
        bridge.setOtherBridge(newOtherBridge);
        bridge.setL1BlockOracle(newOracle);

        assertEq(bridge.bridgeAuthority(), newAuthority, "bridgeAuthority should update");
        assertEq(bridge.rollup(), newRollup, "rollup should update");
        assertEq(bridge.otherBridge(), newOtherBridge, "otherBridge should update");
        assertEq(bridge.l1BlockOracle(), newOracle, "oracle should update");
    }

    function test_adminSetters_zeroAddressAndQueueGuards() public {
        // Zero-address guards on authority and otherBridge.
        vm.expectRevert(abi.encodeWithSelector(IBridgeErrorCodes.ZeroAddressNotAllowed.selector, "bridgeAuthority"));
        bridge.setBridgeAuthority(address(0));

        vm.expectRevert(abi.encodeWithSelector(IBridgeErrorCodes.ZeroAddressNotAllowed.selector, "otherBridge"));
        bridge.setOtherBridge(address(0));

        // QueueNotEmpty guard when unsetting rollup.
        vm.deal(address(this), 1 ether);
        bridge.sendMessage{value: 1}(address(0xDEAD), "");
        assertEq(bridge.sentMessageQueueSize(), 1, "queue should contain one message before unsetting rollup");

        vm.expectRevert(bytes4(keccak256("QueueNotEmpty()")));
        bridge.setRollup(address(0));

        // When queue is empty, rollup can be set to zero.
        Bridge bridgeImpl2 = new Bridge();
        ERC1967Proxy proxy2 = new ERC1967Proxy(
            address(bridgeImpl2),
            abi.encodeCall(
                Bridge.initialize,
                (
                    address(this),
                    INITIAL_AUTHORITY,
                    INITIAL_ROLLUP,
                    INITIAL_DEADLINE,
                    INITIAL_OTHER_BRIDGE,
                    INITIAL_ORACLE
                )
            )
        );
        Bridge freshBridge = Bridge(payable(address(proxy2)));
        assertEq(freshBridge.sentMessageQueueSize(), 0, "fresh bridge queue should be empty");
        freshBridge.setRollup(address(0));
        assertEq(freshBridge.rollup(), address(0), "fresh bridge rollup should be unset successfully");
    }

    function test_setters_revertForNonOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        bridge.setBridgeAuthority(address(0x1));

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        bridge.setRollup(address(0x2));

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        bridge.setL1BlockOracle(address(0x3));

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        bridge.setOtherBridge(address(0x4));
    }
}

