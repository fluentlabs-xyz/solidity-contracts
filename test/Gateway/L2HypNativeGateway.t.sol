// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L2HypNativeGateway} from "../../contracts/gateways/L2HypNativeGateway.sol";
import {
    IL1HypNativeGateway,
    IL2HypNativeGateway,
    IHypNativeGatewayErrors,
    IHypNativeGatewayEvents
} from "../../contracts/interfaces/gateways/IHypNativeGateway.sol";
import {IGatewayBaseErrors, IGatewayBaseEvents} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {IFluentBridge, IFluentBridgeErrors, IFluentBridgeEvents} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {Blacklist} from "../../contracts/blacklist/Blacklist.sol";

import {GatewayBase} from "./Base.t.sol";
import {EthRejecter} from "../mocks/EthRejecter.sol";

contract L2HypNativeGatewayTest is GatewayBase {
    L2HypNativeGateway internal l2Hyp;

    uint32 internal constant TEST_DOMAIN = 8453; // base
    bytes32 internal constant TEST_RECIPIENT = bytes32(uint256(uint160(0x1111111111111111111111111111111111111111)));
    /// @dev Comfortably above {L2HypNativeGateway.MIN_HYP_FEE_NATIVE} (0.001 ether).
    uint256 internal constant TEST_HYP_FEE = 0.01 ether;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployL2HypNativeGateway();
    }

    function _deployL2HypNativeGateway() internal {
        L2HypNativeGateway impl = new L2HypNativeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(L2HypNativeGateway.initialize, (admin, address(bridge))));
        l2Hyp = L2HypNativeGateway(payable(address(proxy)));

        vm.prank(admin);
        l2Hyp.setOtherSideGateway(remoteGateway);

        _registerGateway(address(l2Hyp));
        _registerGateway(remoteGateway);
    }

    function test_initialize_setsDefaults() public view {
        assertEq(l2Hyp.owner(), admin);
        assertEq(l2Hyp.getBridgeContract(), address(bridge));
        assertEq(l2Hyp.getOtherSideGateway(), remoteGateway);
    }

    function test_sendNativeTokens_locksTotalInBridge() public {
        // Bridge fee defaults to 0 in the test setup (gas oracle params zero).
        uint256 amount = 1 ether;
        uint256 total = amount + TEST_HYP_FEE;
        vm.deal(user, total);

        vm.prank(user);
        l2Hyp.sendNativeTokens{value: total}(TEST_DOMAIN, TEST_RECIPIENT, amount, TEST_HYP_FEE);

        assertEq(address(bridge).balance, total, "bridge did not receive amount + hypFee");
    }

    function test_sendNativeTokens_emitsSentMessageWithEncodedPayload() public {
        uint256 amount = 1 ether;
        uint256 total = amount + TEST_HYP_FEE;
        vm.deal(user, total);

        bytes memory expectedPayload = abi.encodeCall(IL1HypNativeGateway.receiveAndForwardNative, (TEST_DOMAIN, TEST_RECIPIENT, amount, user));

        // Match indexed sender/destination + non-indexed payload.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IFluentBridgeEvents.SentMessage(
            address(l2Hyp),
            remoteGateway,
            total,
            0,
            block.chainid,
            0,
            0,
            keccak256(abi.encode(address(l2Hyp), remoteGateway, total, block.chainid, uint256(0), uint256(0), expectedPayload)),
            expectedPayload
        );

        vm.prank(user);
        l2Hyp.sendNativeTokens{value: total}(TEST_DOMAIN, TEST_RECIPIENT, amount, TEST_HYP_FEE);
    }

    function test_sendNativeTokens_excessMsgValuePassesThroughToBridge() public {
        // Anything above `required` passes through as cross-bridge value (joins hypFee buffer on L1).
        uint256 amount = 1 ether;
        uint256 excess = 0.5 ether;
        uint256 total = amount + TEST_HYP_FEE + excess;
        vm.deal(user, total);

        vm.prank(user);
        l2Hyp.sendNativeTokens{value: total}(TEST_DOMAIN, TEST_RECIPIENT, amount, TEST_HYP_FEE);

        assertEq(address(bridge).balance, total, "excess should pass through to bridge value");
    }

    function test_RevertIf_sendNativeTokens_zeroDomain() public {
        uint256 amount = 1 ether;
        uint256 total = amount + TEST_HYP_FEE;
        vm.deal(user, total);

        vm.prank(user);
        vm.expectRevert(IHypNativeGatewayErrors.InvalidTargetDomain.selector);
        l2Hyp.sendNativeTokens{value: total}(0, TEST_RECIPIENT, amount, TEST_HYP_FEE);
    }

    function test_RevertIf_sendNativeTokens_zeroRecipient() public {
        uint256 amount = 1 ether;
        uint256 total = amount + TEST_HYP_FEE;
        vm.deal(user, total);

        vm.prank(user);
        vm.expectRevert(IHypNativeGatewayErrors.ZeroRecipient.selector);
        l2Hyp.sendNativeTokens{value: total}(TEST_DOMAIN, bytes32(0), amount, TEST_HYP_FEE);
    }

    function test_RevertIf_sendNativeTokens_hypFeeBelowMinimum() public {
        uint256 minHypFee = l2Hyp.MIN_HYP_FEE_NATIVE();
        uint256 amount = 1 ether;
        uint256 hypFee = minHypFee - 1;
        uint256 total = amount + hypFee;
        vm.deal(user, total);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IL2HypNativeGateway.InvalidHyperlaneFee.selector, hypFee, minHypFee));
        l2Hyp.sendNativeTokens{value: total}(TEST_DOMAIN, TEST_RECIPIENT, amount, hypFee);
    }

    function test_RevertIf_sendNativeTokens_msgValueBelowRequired() public {
        uint256 amount = 1 ether;
        uint256 required = amount + TEST_HYP_FEE; // bridgeFee = 0 in test setup
        uint256 supplied = required - 1;
        vm.deal(user, supplied);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IHypNativeGatewayErrors.InvalidNativeAmount.selector, supplied, required));
        l2Hyp.sendNativeTokens{value: supplied}(TEST_DOMAIN, TEST_RECIPIENT, amount, TEST_HYP_FEE);
    }

    function test_RevertIf_sendNativeTokens_destinationGatewayNotRegistered() public {
        // Deploy a fresh gateway whose remote peer is never registered on the bridge.
        L2HypNativeGateway impl = new L2HypNativeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(L2HypNativeGateway.initialize, (admin, address(bridge))));
        L2HypNativeGateway local = L2HypNativeGateway(payable(address(proxy)));
        // No setOtherSideGateway — defaults to address(0); bridge rejects.

        uint256 amount = 1 ether;
        uint256 total = amount + TEST_HYP_FEE;
        vm.deal(user, total);

        vm.prank(user);
        vm.expectRevert(IFluentBridgeErrors.GatewayNotWhitelisted.selector);
        local.sendNativeTokens{value: total}(TEST_DOMAIN, TEST_RECIPIENT, amount, TEST_HYP_FEE);
    }

    function test_rescueNative_transfersBalance() public {
        vm.deal(address(l2Hyp), 1 ether);
        uint256 beforeRecipient = recipient.balance;

        vm.prank(admin);
        l2Hyp.rescueNative(payable(recipient), 0.4 ether);

        assertEq(recipient.balance - beforeRecipient, 0.4 ether, "recipient received funds");
        assertEq(address(l2Hyp).balance, 0.6 ether, "gateway balance reduced");
    }

    function test_RevertIf_rescueNative_zeroRecipient() public {
        vm.deal(address(l2Hyp), 1 ether);
        vm.prank(admin);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        l2Hyp.rescueNative(payable(address(0)), 1);
    }

    function test_RevertIf_rescueNative_callerNotOwner() public {
        vm.deal(address(l2Hyp), 1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        l2Hyp.rescueNative(payable(recipient), 1);
    }

    function test_RevertIf_rescueNative_recipientReverts() public {
        address payable rejecter = payable(address(new EthRejecter()));
        vm.deal(address(l2Hyp), 1 ether);

        vm.prank(admin);
        vm.expectRevert(IHypNativeGatewayErrors.RescueFailed.selector);
        l2Hyp.rescueNative(rejecter, 0.1 ether);
    }

    // ─── Inbound: receiveNativeTokens (mirrors NativeGateway.receiveNativeTokens) ─

    function test_receiveNativeTokens_deliversToRecipient() public {
        address from = remoteGateway;
        address to = makeAddr("inboundRecipient");
        uint256 amount = 0.7 ether;

        uint256 prev = to.balance;
        (bytes32 hash, , ) = _relayMessage(
            remoteGateway,
            address(l2Hyp),
            amount,
            abi.encodeCall(IL2HypNativeGateway.receiveNativeTokens, (from, to, amount))
        );

        assertEq(uint256(bridge.getReceivedMessage(hash)), uint256(IFluentBridge.MessageStatus.Success), "bridge should mark Success");
        assertEq(to.balance - prev, amount, "recipient should receive amount");
    }

    function test_receiveNativeTokens_emitsReceivedTokens() public {
        address from = remoteGateway;
        address to = makeAddr("inboundRecipient");
        uint256 amount = 0.5 ether;

        // Register the receive target before the prank inside `_relayMessage` so the strict
        // expectEmit pairing isn't disrupted by a {GatewayRegistered} event.
        _registerGateway(address(l2Hyp));

        vm.expectEmit(true, true, false, true, address(l2Hyp));
        emit IGatewayBaseEvents.ReceivedTokens(from, to, amount);

        _relayMessage(remoteGateway, address(l2Hyp), amount, abi.encodeCall(IL2HypNativeGateway.receiveNativeTokens, (from, to, amount)));
    }

    function test_receiveNativeTokens_marksFailed_whenFromWrongPeer() public {
        address to = makeAddr("inboundRecipient");
        uint256 amount = 0.3 ether;
        address rogue = makeAddr("rogue");

        // Bridge native-sender = rogue ≠ getOtherSideGateway() → peer auth fails, bridge
        // marks Failed.
        (bytes32 hash, , ) = _relayMessage(
            rogue,
            address(l2Hyp),
            amount,
            abi.encodeCall(IL2HypNativeGateway.receiveNativeTokens, (rogue, to, amount))
        );

        assertEq(uint256(bridge.getReceivedMessage(hash)), uint256(IFluentBridge.MessageStatus.Failed), "wrong peer must mark Failed");
        assertEq(to.balance, 0, "recipient must not receive");
    }

    function test_receiveNativeTokens_marksFailed_whenValueMismatch() public {
        address from = remoteGateway;
        address to = makeAddr("inboundRecipient");
        uint256 amountInPayload = 1 ether;
        uint256 amountInValue = 0.5 ether;

        (bytes32 hash, , ) = _relayMessage(
            remoteGateway,
            address(l2Hyp),
            amountInValue,
            abi.encodeCall(IL2HypNativeGateway.receiveNativeTokens, (from, to, amountInPayload))
        );

        assertEq(uint256(bridge.getReceivedMessage(hash)), uint256(IFluentBridge.MessageStatus.Failed), "value mismatch must mark Failed");
    }

    function test_receiveNativeTokens_marksFailed_whenRecipientZero() public {
        address from = remoteGateway;
        uint256 amount = 0.1 ether;

        (bytes32 hash, , ) = _relayMessage(
            remoteGateway,
            address(l2Hyp),
            amount,
            abi.encodeCall(IL2HypNativeGateway.receiveNativeTokens, (from, address(0), amount))
        );

        assertEq(uint256(bridge.getReceivedMessage(hash)), uint256(IFluentBridge.MessageStatus.Failed), "zero recipient must mark Failed");
    }

    function test_receiveNativeTokens_marksFailed_whenRecipientBlacklisted() public {
        Blacklist blImpl = new Blacklist();
        ERC1967Proxy blProxy = new ERC1967Proxy(address(blImpl), abi.encodeCall(Blacklist.initialize, (admin)));
        Blacklist bl = Blacklist(address(blProxy));

        address to = makeAddr("blacklistedRecipient");
        vm.startPrank(admin);
        l2Hyp.setBlacklistRegistry(address(bl));
        bl.setBlacklisted(to, true);
        vm.stopPrank();

        address from = remoteGateway;
        uint256 amount = 0.1 ether;

        (bytes32 hash, , ) = _relayMessage(
            remoteGateway,
            address(l2Hyp),
            amount,
            abi.encodeCall(IL2HypNativeGateway.receiveNativeTokens, (from, to, amount))
        );

        assertEq(
            uint256(bridge.getReceivedMessage(hash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "blacklisted recipient must mark Failed"
        );
        assertEq(to.balance, 0, "blacklisted recipient must not receive");
    }

    function test_receiveNativeTokens_marksFailed_whenRecipientRejectsEth() public {
        address from = remoteGateway;
        address payable rejecter = payable(address(new EthRejecter()));
        uint256 amount = 0.1 ether;

        (bytes32 hash, , ) = _relayMessage(
            remoteGateway,
            address(l2Hyp),
            amount,
            abi.encodeCall(IL2HypNativeGateway.receiveNativeTokens, (from, rejecter, amount))
        );

        assertEq(uint256(bridge.getReceivedMessage(hash)), uint256(IFluentBridge.MessageStatus.Failed), "rejecter must mark Failed");
    }

    function test_RevertIf_receiveNativeTokens_callerNotBridge() public {
        address from = remoteGateway;
        address to = makeAddr("inboundRecipient");
        uint256 amount = 0.1 ether;

        vm.deal(makeAddr("stranger"), amount);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IGatewayBaseErrors.OnlyFluentBridge.selector);
        l2Hyp.receiveNativeTokens{value: amount}(from, to, amount);
    }
}
