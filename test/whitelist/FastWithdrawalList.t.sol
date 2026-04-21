// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {FastWithdrawalList} from "../../contracts/fastlist/FastWithdrawalList.sol";
import {IFastWithdrawalList, IFastWithdrawalListErrors, IFastWithdrawalListEvents} from "../../contracts/interfaces/IFastWithdrawalList.sol";

contract FastWithdrawalListTest is Test {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    address internal gateway = makeAddr("gateway");
    address internal otherGateway = makeAddr("otherGateway");
    address internal token = makeAddr("token");
    address internal otherToken = makeAddr("otherToken");

    FastWithdrawalList internal list;
    bytes32 internal CONSUMER_ROLE;

    function setUp() public {
        FastWithdrawalList impl = new FastWithdrawalList();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(FastWithdrawalList.initialize, (admin)));
        list = FastWithdrawalList(address(proxy));
        CONSUMER_ROLE = list.CONSUMER_ROLE();
    }

    /// @dev Convenience: grant CONSUMER_ROLE to a gateway from the admin context.
    function _grantConsumer(address gateway_) internal {
        vm.prank(admin);
        list.grantRole(CONSUMER_ROLE, gateway_);
    }

    // ============ Initialization ============

    function test_initialize_grantsAdminRole() public view {
        assertTrue(list.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin should hold DEFAULT_ADMIN_ROLE");
        assertFalse(list.hasRole(DEFAULT_ADMIN_ROLE, stranger), "stranger should not hold admin role");
    }

    function test_RevertIf_initialize_zeroAdmin() public {
        FastWithdrawalList impl = new FastWithdrawalList();
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.ZeroAddressNotAllowed.selector, "initialAdmin"));
        new ERC1967Proxy(address(impl), abi.encodeCall(FastWithdrawalList.initialize, (address(0))));
    }

    // ============ registerToken ============

    function test_registerToken_marksRegisteredAndSetsLimits() public {
        vm.expectEmit(true, false, false, true, address(list));
        emit IFastWithdrawalListEvents.TokenRegistered(token, 1 ether, 10 ether);
        vm.prank(admin);
        list.registerToken(token, 1 ether, 10 ether);

        assertTrue(list.isRegistered(token));
        (uint256 hourly, uint256 daily) = list.getLimit(token);
        assertEq(hourly, 1 ether);
        assertEq(daily, 10 ether);
    }

    function test_RevertIf_registerToken_callerNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE));
        list.registerToken(token, 1 ether, 10 ether);
    }

    function test_RevertIf_registerToken_zeroToken() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.ZeroAddressNotAllowed.selector, "token"));
        list.registerToken(address(0), 1 ether, 10 ether);
    }

    function test_RevertIf_registerToken_alreadyRegistered() public {
        vm.prank(admin);
        list.registerToken(token, 1 ether, 10 ether);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.TokenAlreadyRegistered.selector, token));
        list.registerToken(token, 2 ether, 20 ether);
    }

    function test_RevertIf_registerToken_hourlyOverflow() public {
        uint256 over = uint256(type(uint96).max) + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.UsageOverflow.selector, token, over));
        list.registerToken(token, over, 10 ether);
    }

    // ============ deregisterToken ============

    function test_deregisterToken_clearsConfigAndUsage() public {
        vm.prank(admin);
        list.registerToken(token, 1 ether, 10 ether);

        // Build up some usage so we can confirm it's wiped on deregister.
        _grantConsumer(gateway);
        vm.prank(gateway);
        list.consumeUsage(token, 0.5 ether);
        (, uint256 usedBefore, , ) = list.getUsage(token);
        assertEq(usedBefore, 0.5 ether);

        vm.expectEmit(true, false, false, false, address(list));
        emit IFastWithdrawalListEvents.TokenDeregistered(token);
        vm.prank(admin);
        list.unregisterToken(token);

        assertFalse(list.isRegistered(token));
        (, uint256 usedAfter, , ) = list.getUsage(token);
        assertEq(usedAfter, 0, "usage must be wiped");
    }

    function test_RevertIf_deregisterToken_notRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.TokenNotRegistered.selector, token));
        list.unregisterToken(token);
    }

    // ============ setLimit ============

    function test_setLimit_preservesUsage() public {
        vm.prank(admin);
        list.registerToken(token, 5 ether, 10 ether);
        _grantConsumer(gateway);
        vm.prank(gateway);
        list.consumeUsage(token, 3 ether);

        vm.prank(admin);
        list.setLimit(token, 8 ether, 20 ether);

        (uint256 hourly, uint256 daily) = list.getLimit(token);
        assertEq(hourly, 8 ether);
        assertEq(daily, 20 ether);
        (, uint256 hourlyUsed, , uint256 dailyUsed) = list.getUsage(token);
        assertEq(hourlyUsed, 3 ether, "usage must survive limit update");
        assertEq(dailyUsed, 3 ether);
    }

    function test_RevertIf_setLimit_notRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.TokenNotRegistered.selector, token));
        list.setLimit(token, 1 ether, 1 ether);
    }

    // ============ setAlias ============

    function test_setAlias_routesUsageThroughCanonicalBucket() public {
        // Canonical: ETH-style sentinel with 5-ether hourly cap.
        address ethKey = makeAddr("ETH_KEY");
        address wethKey = makeAddr("WETH_KEY");

        vm.prank(admin);
        list.registerToken(ethKey, 5 ether, 10 ether);
        vm.prank(admin);
        list.setAlias(wethKey, ethKey);
        _grantConsumer(gateway);

        // Consume against the alias; canonical bucket is debited.
        vm.prank(gateway);
        list.consumeUsage(wethKey, 2 ether);

        (, uint256 ethUsed, , ) = list.getUsage(ethKey);
        assertEq(ethUsed, 2 ether, "canonical bucket should reflect aliased consumption");
        assertTrue(list.isRegistered(wethKey), "alias view should resolve to registered canonical");
        assertEq(list.getAlias(wethKey), ethKey);

        // Consuming directly against canonical adds to the same bucket.
        vm.prank(gateway);
        list.consumeUsage(ethKey, 1 ether);
        (, ethUsed, , ) = list.getUsage(ethKey);
        assertEq(ethUsed, 3 ether);
    }

    function test_RevertIf_setAlias_targetNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.InvalidAliasTarget.selector, token, otherToken));
        list.setAlias(token, otherToken);
    }

    function test_RevertIf_setAlias_self() public {
        vm.prank(admin);
        list.registerToken(token, 1 ether, 1 ether);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.InvalidAliasTarget.selector, token, token));
        list.setAlias(token, token);
    }

    function test_setAlias_clear() public {
        vm.prank(admin);
        list.registerToken(token, 1 ether, 1 ether);
        vm.prank(admin);
        list.setAlias(otherToken, token);
        assertEq(list.getAlias(otherToken), token);

        vm.prank(admin);
        list.setAlias(otherToken, address(0));
        assertEq(list.getAlias(otherToken), address(0));
    }

    // ============ CONSUMER_ROLE management (via OZ AccessControl) ============

    function test_grantConsumerRole_allowsConsumeAndRevocation() public {
        vm.prank(admin);
        list.registerToken(token, 1 ether, 10 ether);

        // Grant CONSUMER_ROLE via the standard AccessControl API.
        vm.prank(admin);
        list.grantRole(CONSUMER_ROLE, gateway);
        assertTrue(list.hasRole(CONSUMER_ROLE, gateway));

        // Granted consumer can consume.
        vm.prank(gateway);
        list.consumeUsage(token, 0.1 ether);

        // Revoke and verify rejection: AccessControl uses `AccessControlUnauthorizedAccount`.
        vm.prank(admin);
        list.revokeRole(CONSUMER_ROLE, gateway);
        assertFalse(list.hasRole(CONSUMER_ROLE, gateway));
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, gateway, CONSUMER_ROLE));
        list.consumeUsage(token, 0.1 ether);
    }

    function test_RevertIf_grantConsumerRole_callerNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE));
        list.grantRole(CONSUMER_ROLE, gateway);
    }

    // ============ consumeUsage ============

    function test_RevertIf_consumeUsage_callerNotConsumer() public {
        vm.prank(admin);
        list.registerToken(token, 1 ether, 1 ether);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CONSUMER_ROLE));
        list.consumeUsage(token, 0.1 ether);
    }

    function test_RevertIf_consumeUsage_tokenNotRegistered() public {
        _grantConsumer(gateway);

        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.TokenNotRegistered.selector, token));
        list.consumeUsage(token, 0.1 ether);
    }

    function test_consumeUsage_hourlyAndDailyAccumulate() public {
        vm.prank(admin);
        list.registerToken(token, 3 ether, 5 ether);
        _grantConsumer(gateway);

        vm.prank(gateway);
        list.consumeUsage(token, 2 ether);

        (uint256 hourWindow, uint256 hourlyUsed, uint256 dayWindow, uint256 dailyUsed) = list.getUsage(token);
        assertEq(hourWindow, block.timestamp / 1 hours);
        assertEq(dayWindow, block.timestamp / 1 days);
        assertEq(hourlyUsed, 2 ether);
        assertEq(dailyUsed, 2 ether);
    }

    function test_RevertIf_consumeUsage_overHourlyLimit() public {
        vm.prank(admin);
        list.registerToken(token, 3 ether, 5 ether);
        _grantConsumer(gateway);

        vm.prank(gateway);
        list.consumeUsage(token, 2 ether);

        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.HourlyLimitExceeded.selector, token, 2 ether, 2 ether, 3 ether));
        list.consumeUsage(token, 2 ether);
    }

    function test_RevertIf_consumeUsage_overDailyLimit() public {
        vm.prank(admin);
        list.registerToken(token, 0, 3 ether);
        _grantConsumer(gateway);

        vm.prank(gateway);
        list.consumeUsage(token, 2 ether);

        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.DailyLimitExceeded.selector, token, 2 ether, 2 ether, 3 ether));
        list.consumeUsage(token, 2 ether);
    }

    function test_consumeUsage_hourlyResetsAfterWarp() public {
        vm.prank(admin);
        list.registerToken(token, 2 ether, 100 ether);
        _grantConsumer(gateway);

        vm.prank(gateway);
        list.consumeUsage(token, 2 ether);

        vm.warp(block.timestamp + 1 hours);

        // New hourly window — counter reset to zero, then bumped by amount.
        vm.prank(gateway);
        list.consumeUsage(token, 2 ether);

        (, uint256 hourlyUsed, , uint256 dailyUsed) = list.getUsage(token);
        assertEq(hourlyUsed, 2 ether, "hourly window should have reset");
        assertEq(dailyUsed, 4 ether, "daily window keeps accumulating");
    }

    function test_consumeUsage_dailyResetsAfterWarp() public {
        vm.prank(admin);
        list.registerToken(token, 0, 3 ether);
        _grantConsumer(gateway);

        vm.prank(gateway);
        list.consumeUsage(token, 3 ether);

        vm.warp(block.timestamp + 1 days);

        vm.prank(gateway);
        list.consumeUsage(token, 3 ether);
        (, , , uint256 dailyUsed) = list.getUsage(token);
        assertEq(dailyUsed, 3 ether);
    }

    function test_consumeUsage_zeroLimitsDisableTheCheck() public {
        vm.prank(admin);
        list.registerToken(token, 0, 0);
        _grantConsumer(gateway);

        // No caps configured → arbitrary large consumption should be permitted (admin's call).
        vm.prank(gateway);
        list.consumeUsage(token, type(uint96).max);
    }

    function test_RevertIf_consumeUsage_amountOverflow() public {
        vm.prank(admin);
        list.registerToken(token, 0, 0);
        _grantConsumer(gateway);

        uint256 over = uint256(type(uint96).max) + 1;
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IFastWithdrawalListErrors.UsageOverflow.selector, token, over));
        list.consumeUsage(token, over);
    }
}
