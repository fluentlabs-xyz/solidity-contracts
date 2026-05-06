// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Blacklist} from "../../contracts/blacklist/Blacklist.sol";
import {IBlacklist} from "../../contracts/interfaces/IBlacklist.sol";

contract BlacklistTest is Test {
    address internal admin = makeAddr("admin");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");

    Blacklist internal blacklist;

    function setUp() public {
        Blacklist impl = new Blacklist();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Blacklist.initialize, (admin)));
        blacklist = Blacklist(address(proxy));
    }

    function test_setBlacklisted_emitsEventAndStoresStatus() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(blacklist));
        emit IBlacklist.BlacklistStatusUpdated(user, true);
        blacklist.setBlacklisted(user, true);

        assertTrue(blacklist.isBlacklisted(user));
    }

    function test_setBlacklistedBatch_emitsPerAccountAndStoresStatus() public {
        address[] memory accounts = new address[](2);
        accounts[0] = user;
        accounts[1] = other;

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(blacklist));
        emit IBlacklist.BlacklistStatusUpdated(user, true);
        vm.expectEmit(true, false, false, true, address(blacklist));
        emit IBlacklist.BlacklistStatusUpdated(other, true);
        blacklist.setBlacklistedBatch(accounts, true);

        assertTrue(blacklist.isBlacklisted(user));
        assertTrue(blacklist.isBlacklisted(other));
    }

    function test_RevertIf_setBlacklisted_notOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        blacklist.setBlacklisted(user, true);
    }
}
