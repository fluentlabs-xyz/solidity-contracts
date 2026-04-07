// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Blacklist} from "../../contracts/blacklist/Blacklist.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {IGatewayBaseErrors} from "../../contracts/interfaces/gateways/IGatewayBase.sol";

import {BridgeBase} from "./Base.t.sol";

/// @dev Blacklist enforcement lives on {GatewayBase}; the bridge does not apply it.
contract BlacklistBridgeTest is BridgeBase {
    Blacklist internal blacklist;
    NativeGateway internal nativeGw;

    function setUp() public override {
        super.setUp();
        Blacklist blImpl = new Blacklist();
        ERC1967Proxy blProxy = new ERC1967Proxy(address(blImpl), abi.encodeCall(Blacklist.initialize, (admin)));
        blacklist = Blacklist(address(blProxy));

        NativeGateway ngImpl = new NativeGateway();
        ERC1967Proxy ngProxy = new ERC1967Proxy(
            address(ngImpl),
            abi.encodeCall(NativeGateway.initialize, (admin, address(l2Bridge)))
        );
        nativeGw = NativeGateway(payable(address(ngProxy)));
        vm.prank(admin);
        nativeGw.setOtherSideGateway(makeAddr("remoteGw"));

        vm.prank(admin);
        nativeGw.setBlacklistRegistry(address(blacklist));
    }

    function test_sendNativeTokens_revertsWhenSenderBlacklisted() public {
        address bad = makeAddr("badActor");
        vm.prank(admin);
        blacklist.setBlacklisted(bad, true);

        vm.deal(bad, 1 ether);
        vm.prank(bad);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.AddressBlacklisted.selector, bad));
        nativeGw.sendNativeTokens{value: 1 ether}(makeAddr("recipient"));
    }

    function test_sendNativeTokens_succeedsWhenRegistryUnset() public {
        vm.prank(admin);
        nativeGw.setBlacklistRegistry(address(0));

        address user = makeAddr("user");
        vm.prank(admin);
        blacklist.setBlacklisted(user, true);

        vm.deal(user, 1 ether);
        vm.prank(user);
        nativeGw.sendNativeTokens{value: 1 ether}(makeAddr("recipient"));

        assertGt(address(l2Bridge).balance, 0);
    }

    function test_sendMessage_ignoresBlacklistOnBridge() public {
        address bad = makeAddr("badDirect");
        vm.prank(admin);
        blacklist.setBlacklisted(bad, true);

        address dst = makeAddr("dst");
        vm.deal(bad, 1 ether);
        vm.prank(bad);
        l2Bridge.sendMessage{value: 1 ether}(dst, hex"01");
    }
}
