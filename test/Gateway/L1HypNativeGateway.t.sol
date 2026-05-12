// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1HypNativeGateway} from "../../contracts/gateways/L1HypNativeGateway.sol";
import {IL1HypNativeGateway, IHypNativeGatewayErrors, IHypNativeGatewayEvents} from "../../contracts/interfaces/gateways/IHypNativeGateway.sol";
import {IGatewayBaseErrors} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";

import {GatewayBase} from "./Base.t.sol";
import {MockTokenBridge} from "../mocks/MockTokenBridge.sol";

contract L1HypNativeGatewayTest is GatewayBase {
    L1HypNativeGateway internal l1Hyp;
    MockTokenBridge internal warpRoute;

    uint32 internal constant TEST_DOMAIN = 8453;
    bytes32 internal constant TEST_RECIPIENT = bytes32(uint256(uint160(0x1111111111111111111111111111111111111111)));
    /// @dev Dispatch gas portion of the warp route quote (`q[0].amount` in HypNative semantics).
    ///      Lower than `minHypFeeNative` users pay on L2 in tests, so reserve top-up isn't triggered
    ///      on the happy path.
    uint256 internal constant DEFAULT_DISPATCH_GAS = 0.005 ether;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployL1HypNativeGateway();
    }

    function _deployL1HypNativeGateway() internal {
        L1HypNativeGateway impl = new L1HypNativeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(L1HypNativeGateway.initialize, (admin, address(bridge))));
        l1Hyp = L1HypNativeGateway(payable(address(proxy)));

        vm.prank(admin);
        l1Hyp.setOtherSideGateway(remoteGateway);

        _registerGateway(address(l1Hyp));
        _registerGateway(remoteGateway);

        warpRoute = new MockTokenBridge();
        warpRoute.setDispatchGas(DEFAULT_DISPATCH_GAS);

        vm.prank(admin);
        l1Hyp.setWarpRoute(TEST_DOMAIN, address(warpRoute));
    }

    /// @dev Encodes and delivers a `receiveAndForwardNative` message via the bridge's
    ///      relayer path. Returns the message hash + transported value.
    function _relayReceive(uint256 transportedValue, uint256 amount, address fromGateway) internal returns (bytes32 messageHash) {
        bytes memory message = abi.encodeCall(IL1HypNativeGateway.receiveAndForwardNative, (TEST_DOMAIN, TEST_RECIPIENT, amount, user));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(fromGateway, address(l1Hyp), transportedValue, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + transportedValue);
        vm.prank(relayer);
        bridge.receiveMessage(fromGateway, address(l1Hyp), transportedValue, sourceChainId, sourceBlock, nonce, message);
    }

    function test_initialize_setsDefaults() public view {
        assertEq(l1Hyp.owner(), admin);
        assertEq(l1Hyp.getBridgeContract(), address(bridge));
        assertEq(l1Hyp.getOtherSideGateway(), remoteGateway);
        assertEq(l1Hyp.getWarpRoute(TEST_DOMAIN), address(warpRoute));
    }

    function test_receiveAndForwardNative_dispatchesToWarpRoute() public {
        uint256 amount = 1 ether;
        // Bridge transports amount + minHypFee. Quote total at delivery is amount + DEFAULT_DISPATCH_GAS
        // (q[0]=DEFAULT_DISPATCH_GAS, q[1]=amount, q[2]=0); transported is larger so surplus stays on gateway.
        uint256 transported = amount + 0.01 ether;

        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "should succeed");
        assertEq(warpRoute.lastDestination(), TEST_DOMAIN, "destination");
        assertEq(warpRoute.lastRecipient(), TEST_RECIPIENT, "recipient");
        assertEq(warpRoute.lastAmount(), amount, "amount");
        // Sum of all native quotes: dispatchGas + amount + 0 external.
        assertEq(warpRoute.lastValue(), amount + DEFAULT_DISPATCH_GAS, "value forwarded to warp route should equal sum of native quotes");
    }

    function test_receiveAndForwardNative_emitsHyperlaneTransferDispatched() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;
        // Mock messageId — mirrors MockTokenBridge.transferRemote's keccak of (destination, recipient, amount, msg.value).
        // msg.value forwarded to the warp route equals the sum of all three native quotes (dispatchGas + amount + 0).
        bytes32 expectedMessageId = keccak256(abi.encode(TEST_DOMAIN, TEST_RECIPIENT, amount, amount + DEFAULT_DISPATCH_GAS));

        // Indexed topics: domain, recipient, originSender; messageId is non-indexed data.
        vm.expectEmit(true, true, true, true, address(l1Hyp));
        emit IHypNativeGatewayEvents.HyperlaneTransferDispatched(TEST_DOMAIN, TEST_RECIPIENT, amount, user, expectedMessageId);

        _relayReceive(transported, amount, remoteGateway);
    }

    function test_receiveAndForwardNative_topsUpFromReserveWhenQuoteExceedsTransported() public {
        uint256 amount = 1 ether;
        uint256 transported = amount; // no minHypFee transported
        // Total native required = dispatchGas + amount + 0; transported only covers `amount`,
        // so the 0.005 ether dispatchGas portion must come from the gateway reserve.
        warpRoute.setDispatchGas(0.005 ether);

        // Pre-fund the gateway reserve.
        vm.deal(address(l1Hyp), 1 ether);

        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(warpRoute.lastValue(), amount + 0.005 ether, "warp route should receive full quote sum");
        assertEq(address(l1Hyp).balance, 1 ether - 0.005 ether, "reserve depleted by top-up");
    }

    function test_receiveAndForwardNative_marksFailed_whenReserveDepleted() public {
        uint256 amount = 1 ether;
        // Transport exact `amount`; dispatchGas of 1 ether requires reserve top-up beyond what's funded.
        warpRoute.setDispatchGas(1 ether);

        bytes32 messageHash = _relayReceive(amount, amount, remoteGateway);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "ReserveDepleted should fail");
    }

    function test_receiveAndForwardNative_marksFailed_whenBatchPreconfirmed() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        _mockBridgePreconfirmed(true);
        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "preconfirmed batch must block");
    }

    function test_receiveAndForwardNative_marksFailed_whenDomainUnsupported() public {
        // Encode for a different domain than the one configured.
        uint32 otherDomain = 42161; // arbitrum
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        bytes memory message = abi.encodeCall(IL1HypNativeGateway.receiveAndForwardNative, (otherDomain, TEST_RECIPIENT, amount, user));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(l1Hyp), transported, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + transported);
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(l1Hyp), transported, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "unsupported domain should fail");
    }

    function test_receiveAndForwardNative_marksFailed_whenSenderNotPeer() public {
        address wrongRemote = makeAddr("wrongRemote");
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        bytes32 messageHash = _relayReceive(transported, amount, wrongRemote);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "wrong sender should fail");
    }

    function test_receiveAndForwardNative_marksFailed_whenZeroRecipient() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        bytes memory message = abi.encodeCall(IL1HypNativeGateway.receiveAndForwardNative, (TEST_DOMAIN, bytes32(0), amount, user));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(l1Hyp), transported, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + transported);
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(l1Hyp), transported, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_RevertIf_receiveAndForwardNative_callerNotBridge() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.OnlyFluentBridge.selector);
        l1Hyp.receiveAndForwardNative{value: 1 ether}(TEST_DOMAIN, TEST_RECIPIENT, 1 ether, user);
    }

    function test_setWarpRoute_updatesAndEmits() public {
        address newRoute = address(new MockTokenBridge());

        vm.expectEmit(true, true, true, true, address(l1Hyp));
        emit IHypNativeGatewayEvents.WarpRouteUpdated(TEST_DOMAIN, address(warpRoute), newRoute);

        vm.prank(admin);
        l1Hyp.setWarpRoute(TEST_DOMAIN, newRoute);

        assertEq(l1Hyp.getWarpRoute(TEST_DOMAIN), newRoute);
    }

    function test_RevertIf_setWarpRoute_warpRouteNotAContract() public {
        address eoa = makeAddr("eoa");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IHypNativeGatewayErrors.WarpRouteNotAContract.selector, eoa));
        l1Hyp.setWarpRoute(TEST_DOMAIN, eoa);
    }

    function test_setWarpRoute_clearsRouteWhenZero() public {
        // address(0) is the documented "clear" sentinel and must bypass the code-length check.
        vm.prank(admin);
        l1Hyp.setWarpRoute(TEST_DOMAIN, address(0));
        assertEq(l1Hyp.getWarpRoute(TEST_DOMAIN), address(0));
    }

    function test_RevertIf_setWarpRoute_callerNotOwner() public {
        vm.prank(stranger());
        vm.expectRevert();
        l1Hyp.setWarpRoute(TEST_DOMAIN, address(0xdead));
    }

    function test_rescueNative_transfersBalance() public {
        vm.deal(address(l1Hyp), 1 ether);
        uint256 beforeRecipient = recipient.balance;

        vm.prank(admin);
        l1Hyp.rescueNative(payable(recipient), 0.4 ether);

        assertEq(recipient.balance - beforeRecipient, 0.4 ether);
        assertEq(address(l1Hyp).balance, 0.6 ether);
    }

    function test_RevertIf_rescueNative_zeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        l1Hyp.rescueNative(payable(address(0)), 1);
    }

    function test_RevertIf_rescueNative_callerNotOwner() public {
        vm.prank(stranger());
        vm.expectRevert();
        l1Hyp.rescueNative(payable(recipient), 1);
    }

    /// @dev Helper because `GatewayBase.t.sol` doesn't declare `stranger`.
    function stranger() internal returns (address) {
        return makeAddr("stranger");
    }
}
