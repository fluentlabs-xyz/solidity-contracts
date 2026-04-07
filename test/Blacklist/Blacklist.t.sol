// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {Blacklist} from "../../contracts/blacklist/Blacklist.sol";

contract BlacklistTest is Test {
    address internal admin = makeAddr("admin");
    Blacklist internal blacklist;

    function setUp() public {
        Blacklist impl = new Blacklist();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Blacklist.initialize, (admin)));
        blacklist = Blacklist(address(proxy));
    }

    function test_setBlacklisted_blocksQuery() public {
        address bad = makeAddr("bad");
        assertFalse(blacklist.isBlacklisted(bad));

        vm.prank(admin);
        blacklist.setBlacklisted(bad, true);
        assertTrue(blacklist.isBlacklisted(bad));

        vm.prank(admin);
        blacklist.setBlacklisted(bad, false);
        assertFalse(blacklist.isBlacklisted(bad));
    }

    function test_setBlacklistedBatch() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address[] memory addrs = new address[](2);
        addrs[0] = a;
        addrs[1] = b;

        vm.prank(admin);
        blacklist.setBlacklistedBatch(addrs, true);
        assertTrue(blacklist.isBlacklisted(a));
        assertTrue(blacklist.isBlacklisted(b));

        vm.prank(admin);
        blacklist.setBlacklistedBatch(addrs, false);
        assertFalse(blacklist.isBlacklisted(a));
    }

    function test_RevertIf_setBlacklisted_notOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        blacklist.setBlacklisted(makeAddr("x"), true);
    }
}
