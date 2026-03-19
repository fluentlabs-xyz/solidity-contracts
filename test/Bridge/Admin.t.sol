// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";

contract BridgeAdminTest is Test {
    address internal admin;
    address internal pauser;
    address internal relayer;
    address internal stranger;

    L1FluentBridge internal l1Bridge;
    L2FluentBridge internal l2Bridge;

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        relayer = makeAddr("relayer");
        stranger = makeAddr("stranger");

        FluentBridgeStorageLayout.InitConfiguration memory cfg = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: pauser,
            relayerRole: relayer,
            otherBridge: makeAddr("otherBridge")
        });

        L1FluentBridge l1Impl = new L1FluentBridge();
        ERC1967Proxy l1Proxy = new ERC1967Proxy(
            address(l1Impl),
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(cfg), makeAddr("rollupA")))
        );
        l1Bridge = L1FluentBridge(payable(address(l1Proxy)));

        L2FluentBridge l2Impl = new L2FluentBridge();
        ERC1967Proxy l2Proxy = new ERC1967Proxy(
            address(l2Impl),
            abi.encodeCall(L2FluentBridge.initialize, (abi.encode(cfg), 100, makeAddr("l1BlockOracleA")))
        );
        l2Bridge = L2FluentBridge(payable(address(l2Proxy)));
    }

    function test_l1_admin_can_setOtherBridge() public {
        address next = makeAddr("nextL1OtherBridge");
        vm.prank(admin);
        l1Bridge.setOtherBridge(next);
        assertEq(l1Bridge.getOtherBridge(), next);
    }

    function test_l1_setOtherBridge_reverts_for_non_admin() public {
        vm.expectRevert();
        vm.prank(stranger);
        l1Bridge.setOtherBridge(makeAddr("nextL1OtherBridge"));
    }

    function test_l1_setOtherBridge_reverts_on_zero_address() public {
        vm.expectRevert();
        vm.prank(admin);
        l1Bridge.setOtherBridge(address(0));
    }

    function test_l1_admin_can_setExecuteGasLimit() public {
        vm.prank(admin);
        l1Bridge.setExecuteGasLimit(250_000);
        assertEq(l1Bridge.getExecuteGasLimit(), 250_000);
    }

    function test_l1_setExecuteGasLimit_reverts_on_zero() public {
        vm.expectRevert();
        vm.prank(admin);
        l1Bridge.setExecuteGasLimit(0);
    }

    function test_l1_admin_can_setRelayerRole() public {
        address nextRelayer = makeAddr("nextRelayerL1");
        vm.prank(admin);
        l1Bridge.setRelayerRole(nextRelayer);
        assertTrue(l1Bridge.hasRole(l1Bridge.RELAYER_ROLE(), nextRelayer));
    }

    function test_l1_setRollup_access_and_zero_checks() public {
        vm.expectRevert();
        vm.prank(stranger);
        l1Bridge.setRollup(makeAddr("rollupB"));

        vm.expectRevert();
        vm.prank(admin);
        l1Bridge.setRollup(address(0));
    }

    function test_l1_admin_can_setRollup() public {
        address nextRollup = makeAddr("rollupB");
        vm.prank(admin);
        l1Bridge.setRollup(nextRollup);
        assertEq(l1Bridge.getRollup(), nextRollup);
    }

    function test_l2_admin_can_setReceiveMessageDeadline() public {
        vm.prank(admin);
        l2Bridge.setReceiveMessageDeadline(777);
        assertEq(l2Bridge.getReceiveMessageDeadline(), 777);
    }

    function test_l2_setReceiveMessageDeadline_access_and_zero_checks() public {
        vm.expectRevert();
        vm.prank(stranger);
        l2Bridge.setReceiveMessageDeadline(777);

        vm.expectRevert();
        vm.prank(admin);
        l2Bridge.setReceiveMessageDeadline(0);
    }

    function test_l2_admin_can_setL1BlockOracle() public {
        address nextOracle = makeAddr("l1BlockOracleB");
        vm.prank(admin);
        l2Bridge.setL1BlockOracle(nextOracle);
        assertEq(l2Bridge.getL1BlockOracle(), nextOracle);
    }

    function test_l2_setL1BlockOracle_access_and_zero_checks() public {
        vm.expectRevert();
        vm.prank(stranger);
        l2Bridge.setL1BlockOracle(makeAddr("l1BlockOracleB"));

        vm.expectRevert();
        vm.prank(admin);
        l2Bridge.setL1BlockOracle(address(0));
    }

    function test_pause_unpause_only_pauser_role() public {
        vm.expectRevert();
        vm.prank(stranger);
        l1Bridge.pause();

        vm.prank(pauser);
        l1Bridge.pause();
        assertTrue(l1Bridge.paused());

        vm.expectRevert();
        vm.prank(stranger);
        l1Bridge.unpause();

        vm.prank(pauser);
        l1Bridge.unpause();
        assertTrue(!l1Bridge.paused());
    }
}
